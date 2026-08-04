import Foundation

/// A finalized ambient context snapshot emitted to the local JSONL stream.
struct AmbientStreamEvent: Codable, Sendable {
    let id: String
    let timestamp: String
    let appName: String
    let bundleId: String
    let windowTitle: String?
    let browserURL: String?
    let codeFileName: String?
    let slackRecipient: String?
    let focusedFieldContent: String?
    let visibleTextSnippets: [String]?
    let dwellDurationSeconds: Double?
    let clipboardText: String?
    let browserTabs: [String]?
    let notificationAppName: String?
    let notificationBundleId: String?
    let notificationTitle: String?
    let notificationBody: String?
    let notificationURL: String?
    let notificationReceivedAt: String?
}
