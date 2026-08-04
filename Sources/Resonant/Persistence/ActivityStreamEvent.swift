import Foundation

/// A single activity event emitted to the local JSONL stream.
struct ActivityStreamEvent: Codable, Sendable {

    let id: String
    let timestamp: String
    let type: EventType

    enum EventType: String, Codable, Sendable {
        case dictation
        case memo
        case meeting
    }

    // Content
    let text: String
    let rawTranscript: String?
    let selectedText: String?

    // Context
    let appName: String?
    let bundleId: String?
    let windowTitle: String?
    let browserURL: String?
    let codeFileName: String?
    let slackRecipient: String?
    let focusedFieldContent: String?
    let visibleTextSnippets: [String]?

    // Metrics
    let durationSeconds: Double
    let wordCount: Int
    let mode: String

    // Audio (relative to App Support, e.g. "stream/audio/{uuid}.caf")
    let audioPath: String?

    // Delivery (dictation only)
    let delivery: Delivery?

    struct Delivery: Codable, Sendable {
        let autoPasted: Bool
        let autoSent: Bool
        let copiedToClipboard: Bool
    }

    // Memo only
    let memoTitle: String?

    // Meeting only
    let meetingTitle: String?
}
