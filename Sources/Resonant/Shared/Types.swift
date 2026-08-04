import Foundation

// MARK: - Dictation

enum DictationMode: String, Codable, Sendable {
    case dictation
    case memo
    case command
}

enum HotkeyTrigger: Hashable, Equatable {
    case fn
    case rightOption
    case custom(keyCode: UInt16)

    var rawValue: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "rightOption"
        case .custom(let keyCode): "custom:\(keyCode)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "fn": self = .fn
        case "rightOption": self = .rightOption
        default:
            if rawValue.hasPrefix("custom:"),
               let code = UInt16(rawValue.dropFirst(7)) {
                self = .custom(keyCode: code)
            } else {
                return nil
            }
        }
    }

    var displayName: String {
        switch self {
        case .fn: "FN / Globe"
        case .rightOption: "Right Option"
        case .custom(let keyCode): KeyCodeNames.name(for: keyCode)
        }
    }

    var shortName: String {
        switch self {
        case .fn: "FN"
        case .rightOption: "Option"
        case .custom(let keyCode): KeyCodeNames.shortName(for: keyCode)
        }
    }

    /// Well-known presets shown in onboarding and menus.
    static let presets: [HotkeyTrigger] = [.fn, .rightOption]

    var isAllowedAsGlobalTrigger: Bool {
        switch self {
        case .fn, .rightOption:
            return true
        case .custom(let keyCode):
            return Self.isAllowedCustomKeyCode(keyCode)
        }
    }

    static func isAllowedCustomKeyCode(_ keyCode: UInt16) -> Bool {
        KeyCodeNames.isModifierKey(keyCode) || KeyCodeNames.isFunctionKey(keyCode)
    }

    static func deduplicated(_ triggers: [HotkeyTrigger]) -> [HotkeyTrigger] {
        var normalized: [HotkeyTrigger] = []
        var seen: Set<HotkeyTrigger> = []

        for trigger in triggers {
            guard trigger.isAllowedAsGlobalTrigger else { continue }
            guard seen.insert(trigger).inserted else { continue }
            normalized.append(trigger)
        }

        return normalized
    }

    static func normalizedList(_ triggers: [HotkeyTrigger], fallback: HotkeyTrigger = .fn) -> [HotkeyTrigger] {
        var normalized = deduplicated(triggers)

        if normalized.isEmpty {
            normalized.append(fallback)
        }

        return normalized
    }
}

extension HotkeyTrigger: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = HotkeyTrigger(rawValue: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid HotkeyTrigger: \(string)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum HotkeyMode: String, Codable, CaseIterable {
    case hold   // press = start, release = stop
    case toggle // tap = start/stop for dictation; memos stay hold-based

    var displayName: String {
        switch self {
        case .hold: "Hold to talk"
        case .toggle: "Tap to start / stop"
        }
    }

    static var allCases: [HotkeyMode] {
        [.hold, .toggle]
    }

    var normalized: HotkeyMode {
        self
    }
}

enum OverlayMode: String, Codable, CaseIterable, Sendable {
    case notch
    case panel

    var displayName: String {
        switch self {
        case .notch: "Minimal"
        case .panel: "Expanded"
        }
    }
}

enum PasteDeliveryMode: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case accessibility = "accessibility"
    case clipboard = "clipboard"
    case directTyping = "direct_typing"

    static let settingsOrder: [PasteDeliveryMode] = [
        .automatic,
        .clipboard,
        .directTyping,
        .accessibility,
    ]

    var displayName: String {
        switch self {
        case .automatic: "Auto (recommended)"
        case .accessibility: "Accessibility insert"
        case .clipboard: "Clipboard paste"
        case .directTyping: "Direct typing"
        }
    }

    var controlLabel: String {
        switch self {
        case .automatic: "Auto"
        case .accessibility: "Accessibility"
        case .clipboard: "Clipboard"
        case .directTyping: "Typing"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Resonant chooses the safest route for the target app."
        case .accessibility:
            return "Tries macOS Accessibility only. Slow and limited to native fields; blocked attempts fall back to copying."
        case .clipboard:
            return "Writes to the clipboard and sends Command-V. If the target blocks paste, the text remains copied."
        case .directTyping:
            return "Types characters directly. Useful for some terminals, but slower and less reliable in rich editors."
        }
    }
}

/*
enum BYOKProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}
*/

struct SelectionRange: Sendable, Equatable {
    let location: Int
    let length: Int
}

struct DictationCaptureDiagnostics: Sendable, Equatable {
    let sampleCount: Int
    let sampleRate: Int

    init(sampleCount: Int, sampleRate: Int = 16_000) {
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
    }

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / Double(sampleRate)
    }

    var durationMilliseconds: Int {
        max(0, Int((duration * 1000).rounded()))
    }
}

struct DictationSegmentRecoveryTrace: Sendable, Equatable {
    let attempted: Bool
    let used: Bool
    let outcome: String
    let originalWordCount: Int
    let recoveredWordCount: Int?
    let speechSegmentCount: Int?
    let voicedDurationSeconds: TimeInterval?
    let segmenterSource: String?

    static func skipped(
        outcome: String,
        originalTranscript: String,
        speechSegmentCount: Int? = nil,
        voicedDurationSeconds: TimeInterval? = nil,
        segmenterSource: String? = nil
    ) -> Self {
        Self(
            attempted: false,
            used: false,
            outcome: outcome,
            originalWordCount: Self.wordCount(in: originalTranscript),
            recoveredWordCount: nil,
            speechSegmentCount: speechSegmentCount,
            voicedDurationSeconds: voicedDurationSeconds,
            segmenterSource: segmenterSource
        )
    }

    static func attempted(
        outcome: String,
        used: Bool,
        originalTranscript: String,
        recoveredTranscript: String,
        speechSegmentCount: Int,
        voicedDurationSeconds: TimeInterval,
        segmenterSource: String
    ) -> Self {
        Self(
            attempted: true,
            used: used,
            outcome: outcome,
            originalWordCount: Self.wordCount(in: originalTranscript),
            recoveredWordCount: Self.wordCount(in: recoveredTranscript),
            speechSegmentCount: speechSegmentCount,
            voicedDurationSeconds: voicedDurationSeconds,
            segmenterSource: segmenterSource
        )
    }

    private static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

struct DictationSegmentRecoveryResult: Sendable, Equatable {
    let recoveredTranscript: String?
    let trace: DictationSegmentRecoveryTrace
}

struct TranscriptionResult: Sendable {
    let text: String
    let rawTranscript: String
    /// Raw transcript with `PauseSegmenter.pauseMarker` at real speech pauses.
    /// nil when timings were unavailable or misaligned (e.g. segment
    /// recovery re-decoded the audio). Consumed by cloud cleanup as
    /// disfluency-detection context; never delivered to the user.
    let pauseAnnotatedTranscript: String?
    let duration: TimeInterval
    let captureDiagnostics: DictationCaptureDiagnostics?
    let recognitionDiagnostics: DictationAudioAnalyzer.Diagnostics?
    let segmentRecoveryTrace: DictationSegmentRecoveryTrace?
    let postProcessingTrace: PostProcessingTrace?
    /// Text-free proof of learned packet entities considered, matched, and
    /// actually replaced by the deterministic local repair consumer.
    let contextEntityRepairProvenance: ContextualEntityRepairProvenance
    /// Text-free per-family opportunity/application record from local
    /// post-processing. It is only a candidate: the physical delivery
    /// boundary narrows it against downstream transforms and target-observed
    /// inserted text before correction readback may confirm anything.
    let styleApplicationProvenance: StyleApplicationProvenance
    let recordingURL: URL?
    let selectedText: String?
    let selectedRange: SelectionRange?
    let targetApp: String?
    let targetBundleId: String?
    let windowTitle: String?
    let browserURL: String?
    let codeFileName: String?
    let slackRecipient: String?
    let focusedFieldContent: String?
    let visibleTextSnippets: [String]?
    let contextPacket: ContextPacket?
    /// Resolves to rich AX metadata (code files, Slack members, visible text)
    /// after delivery has landed. `nil` when context metadata is disabled or
    /// when the caller doesn't intend to attach cold context.
    let coldContextTask: Task<ContextExtractor.ColdContext, Never>?
    /// Decode-time vocabulary-boost decisions for this dictation. nil when
    /// the boost pass never reached the decision stage (feature off, recovery
    /// re-decode, non-boosting backend) or when a segment-recovery re-decode
    /// replaced the transcript the audit described.
    let vocabularyBoostAudit: VocabularyBoostAudit?

    init(
        text: String,
        rawTranscript: String,
        pauseAnnotatedTranscript: String? = nil,
        duration: TimeInterval,
        captureDiagnostics: DictationCaptureDiagnostics?,
        recognitionDiagnostics: DictationAudioAnalyzer.Diagnostics? = nil,
        segmentRecoveryTrace: DictationSegmentRecoveryTrace? = nil,
        postProcessingTrace: PostProcessingTrace? = nil,
        contextEntityRepairProvenance: ContextualEntityRepairProvenance = .none,
        styleApplicationProvenance: StyleApplicationProvenance = .none,
        recordingURL: URL?,
        selectedText: String?,
        selectedRange: SelectionRange?,
        targetApp: String?,
        targetBundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        codeFileName: String?,
        slackRecipient: String?,
        focusedFieldContent: String?,
        visibleTextSnippets: [String]?,
        contextPacket: ContextPacket? = nil,
        coldContextTask: Task<ContextExtractor.ColdContext, Never>? = nil,
        vocabularyBoostAudit: VocabularyBoostAudit? = nil
    ) {
        self.vocabularyBoostAudit = vocabularyBoostAudit
        self.text = text
        self.rawTranscript = rawTranscript
        self.pauseAnnotatedTranscript = pauseAnnotatedTranscript
        self.duration = duration
        self.captureDiagnostics = captureDiagnostics
        self.recognitionDiagnostics = recognitionDiagnostics
        self.segmentRecoveryTrace = segmentRecoveryTrace
        self.postProcessingTrace = postProcessingTrace
        self.contextEntityRepairProvenance = contextEntityRepairProvenance
        self.styleApplicationProvenance = styleApplicationProvenance
        self.recordingURL = recordingURL
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.targetApp = targetApp
        self.targetBundleId = targetBundleId
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.codeFileName = codeFileName
        self.slackRecipient = slackRecipient
        self.focusedFieldContent = focusedFieldContent
        self.visibleTextSnippets = visibleTextSnippets
        self.contextPacket = contextPacket
        self.coldContextTask = coldContextTask
    }
}

// MARK: - Notch state

enum NotchOverlayState: Equatable {
    case idle
    case recording(mode: DictationMode, level: Float, elapsed: TimeInterval)
    case processing(progress: Double, stage: String)
    case done(text: String)
    case notice(Notice)
    case error(message: String, subtype: ErrorSubtype)
    case hotMic(level: Float, liveText: String)
    case command(stage: CommandStage)

    enum CommandStage: Equatable {
        case listening(level: Float, elapsed: TimeInterval)
        case awaitingFollowUp(level: Float, elapsed: TimeInterval, status: String)
        case thinking(status: String)
        case result(text: String, success: Bool)
    }

    struct Notice: Equatable {
        let title: String
        let detail: String?
        let icon: String

        init(title: String, detail: String? = nil, icon: String = "info.circle.fill") {
            self.title = title
            self.detail = detail
            self.icon = icon
        }
    }

    enum ErrorSubtype: Equatable {
        case transcription
        case paste
        case generic
        case meetingSystemAudio
        case model
        case microphone
    }
}

// MARK: - Progression

enum ExpressionType: Sendable {
    case levelUp(levelName: String)
    case hotStreak(count: Int)
    case achievement(title: String, message: String)
}

// MARK: - Feed

enum FeedItemKind: String, Codable {
    case dictation
    case memo
    case achievement
    case journal
    case meeting
}

struct FeedItem: Identifiable {
    let id: UUID
    let kind: FeedItemKind
    let text: String
    let date: Date
    let appName: String?
    let bundleId: String?
    let contextLabel: String?
    let windowTitle: String?
    let browserURL: String?
    let audioPath: String?
    let metadata: [String: String]
}

extension FeedItem {
    var durationSeconds: Int? {
        if let stored = metadata["durationSeconds"], let seconds = Int(stored) {
            return seconds
        }
        guard let stored = metadata["duration"]?
            .replacingOccurrences(of: "s", with: ""),
              let seconds = Int(stored)
        else {
            return nil
        }
        return seconds
    }

    var feedDurationText: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        if durationSeconds < 60 {
            return "\(durationSeconds)s"
        }

        let minutes = durationSeconds / 60
        let remainingSeconds = durationSeconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    var wordCount: Int? {
        guard let stored = metadata["wordCount"], let count = Int(stored) else {
            return nil
        }
        return count
    }

    var feedWordCountText: String? {
        guard let wordCount, wordCount > 0 else { return nil }
        return wordCount == 1 ? "1 word" : "\(wordCount) words"
    }

    var feedMemoTitle: String? {
        metadata["title"]
    }

    var isExpandableInFeed: Bool {
        text.count > 180 || text.split(whereSeparator: \.isNewline).count > 3
    }
}
